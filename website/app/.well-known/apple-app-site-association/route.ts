const ASSOCIATION = {
  applinks: {
    apps: [],
    details: [
      {
        appID: "T7GYB573Y6.app.rxlab.rxcodemobile",
        paths: ["/pair", "/pair/*"],
      },
    ],
  },
};

export function GET() {
  return Response.json(ASSOCIATION, {
    headers: {
      "content-type": "application/json",
    },
  });
}
